// SPDX-License-Identifier: GPL-3.0
/*
    Copyright 2021 0KIMS association.

    This file is generated with [snarkJS](https://github.com/iden3/snarkjs).

    snarkJS is a free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    snarkJS is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public
    License for more details.

    You should have received a copy of the GNU General Public License
    along with snarkJS. If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity ^0.8.24;

contract AggVerifier_N1_m16_w32 {
    // Scalar field size
    uint256 constant r    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data
    uint256 constant alphax  = 16428432848801857252194528405604668803277877773566238944394625302971855135431;
    uint256 constant alphay  = 16846502678714586896801519656441059708016666274385668027902869494772365009666;
    uint256 constant betax1  = 3182164110458002340215786955198810119980427837186618912744689678939861918171;
    uint256 constant betax2  = 16348171800823588416173124589066524623406261996681292662100840445103873053252;
    uint256 constant betay1  = 4920802715848186258981584729175884379674325733638798907835771393452862684714;
    uint256 constant betay2  = 19687132236965066906216944365591810874384658708175106803089633851114028275753;
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant deltax1 = 18174291495690432556373766606925390544589449730591196983441068545270078386778;
    uint256 constant deltax2 = 6912208826190570948858524189569167898354915089367777074132458535779866936817;
    uint256 constant deltay1 = 12545537329697146623935420616272510708687219588505309086946055997487252235172;
    uint256 constant deltay2 = 17131892431419817127005581203372941586995931863615437347381962587104234047045;

    
    uint256 constant IC0x = 14364259545616893199396463687036675217322855639454053922059923479483805832872;
    uint256 constant IC0y = 8011632617065488983743799488187245100188600361166992413454978402836247791783;
    
    uint256 constant IC1x = 18736471727614526524640290450139821915935980906052069437414384337799705395232;
    uint256 constant IC1y = 17353759298108464687909663235120739531522783104973964145538677418501933579350;
    
    uint256 constant IC2x = 5052743147696548585542091343250905971147549899727790082023064632098955552276;
    uint256 constant IC2y = 15987742356061218714803481456606482564894741832416785861896447263892660695995;
    
    uint256 constant IC3x = 17355115214795173062904978461846367185990717767695426469185030087048901933792;
    uint256 constant IC3y = 13955898927765490540483199554674366575452382668641284144577158436601085492739;
    
    uint256 constant IC4x = 11480159664855014613895777118244229958642984818656610329975306130308321217395;
    uint256 constant IC4y = 10631529461527786200335956914841252172004948969363215439706806447613131024127;
    
    uint256 constant IC5x = 9175374181824447804187162080473818036134150338350681879342783726287044458918;
    uint256 constant IC5y = 7053503643553613209180027362766610525839273324868689616393967575480831356465;
    
    uint256 constant IC6x = 15354273849694572299219777069241379668092580495655598475897581098612784588718;
    uint256 constant IC6y = 20290464159447957159696234819147174215778252697633926561789120688496911091639;
    
    uint256 constant IC7x = 20754534822373229036956160640993906665584715436962494703181657757577189682805;
    uint256 constant IC7y = 15264328721188557070886069179042391241148571088993651475010886191011692307622;
    
    uint256 constant IC8x = 20190344628180703131020170867442737407438825198057657799102272293665606903059;
    uint256 constant IC8y = 9922144220888656361190963363379012523873293468407395682593324679243412033597;
    
    uint256 constant IC9x = 1544382382933192322832236813119381997377362470091844741680116730940893262313;
    uint256 constant IC9y = 10106987029965156597326944038519496961541121746228237940360840960589566909174;
    
    uint256 constant IC10x = 11662080232471031558893986269414985598189971890711463031135856112377825367154;
    uint256 constant IC10y = 18223860625853433317666072354612537820105186945373809884764725152513175485599;
    
    uint256 constant IC11x = 10413972695281599164288069939290404482375121153636838567455490506320234115400;
    uint256 constant IC11y = 14624394490968559643998678387839761854527085098215649092974682212274328347655;
    
    uint256 constant IC12x = 2457228564733920218851377451438173465530693068508011068245540395872029492344;
    uint256 constant IC12y = 19656256152997711288789557729489821793972318398123575985870174672637844342728;
    
    uint256 constant IC13x = 17891782721687828762720962197293735355283470949921276721183545504554385384449;
    uint256 constant IC13y = 5226174591359707741318268940989370372200740158572719655637631425497408681883;
    
    uint256 constant IC14x = 21095654112264385179035198463567155109668888965898109360400450327641937531009;
    uint256 constant IC14y = 3126145849175664292706947272351738387022514848508658090349737669475322400890;
    
    uint256 constant IC15x = 3341161045860817407599126571674201388324725693530036568529529691944177335513;
    uint256 constant IC15y = 16633754229986182346417385047974802667792007179422460082223734579594287626081;
    
    uint256 constant IC16x = 10792709569921931847565979663422671977694029231111980567477919255869040351676;
    uint256 constant IC16y = 8302231039161182645424541276613438500421818702198213312539983270402664377147;
    
    uint256 constant IC17x = 9852980584633642590159574560603906013961279097263174278632739117942223993591;
    uint256 constant IC17y = 3470064444446535010086540054673941394297157902396459059240349604630197802998;
    
    uint256 constant IC18x = 4120212941223136650907730318982295590239084143561424694328573605535066498429;
    uint256 constant IC18y = 8724570776053972895762856674704049608680014649374229107063521994847703735478;
    
    uint256 constant IC19x = 6973997190931031422178809838033649801046615748806505178581970555029887451188;
    uint256 constant IC19y = 16615687890830395982217351545208946960104744745452301997295229172332514177417;
    
    uint256 constant IC20x = 11873701560776604580655822339013437204209077264431028934523992249450494843591;
    uint256 constant IC20y = 2138020012469183803105335312593332001291564192000676437563613341286386148373;
    
    uint256 constant IC21x = 17581494551451431147185039480559596379791751163532308867011325623963068149195;
    uint256 constant IC21y = 10429968403627296785217310915597445285352265128139433663872467376402001150340;
    
    uint256 constant IC22x = 7825914111470473943227957453940600673979096713038634477932560460202859135671;
    uint256 constant IC22y = 4788289528028733456852160492957853233623827448891423184852396880510148032145;
    
    uint256 constant IC23x = 21452415950743398012768097265039850737993068114826096713815499712973188280857;
    uint256 constant IC23y = 19028651662517447781438249309441746253422410140397831435868442637993051358322;
    
    uint256 constant IC24x = 14263607749946346505834372385009513674189804261908935904759084151738789546016;
    uint256 constant IC24y = 13761453585365288559243519662571280851670263982681783645618252173103455502541;
    
    uint256 constant IC25x = 8681890697652374058474414126950404862043656441907196817013387696621481941239;
    uint256 constant IC25y = 7853204423303293197371460365420190814054212583876496422241373077284246625360;
    
    uint256 constant IC26x = 1593761160929021022912022634922726385563193019796506816944853759877614742591;
    uint256 constant IC26y = 17334973148875971205091388890379067639855493309637500098663322137840948055916;
    
    uint256 constant IC27x = 7569266740003551718748730517133923274855337469304677454383552969071113981050;
    uint256 constant IC27y = 850809074909301110375005668046103465357277058324818129254155925449980901732;
    
    uint256 constant IC28x = 8049254426413804368988749918804294678588835980613454528407205755662710327813;
    uint256 constant IC28y = 791766227962628951499653524196563021414514859377038534488368052236129353691;
    
    uint256 constant IC29x = 9733995165806020941819731835571815594523318807441974219698764729665268305019;
    uint256 constant IC29y = 18596675131833338320120346267067169200631160024083547818059217061390401075338;
    
    uint256 constant IC30x = 3009973351322961849576940901966522032621020950153113613451268127967640971213;
    uint256 constant IC30y = 2665156994044594760547264243461390770386333455518216366902170975027328633136;
    
    uint256 constant IC31x = 321889103089493637411249902032446177370253323752166487830767574183167457608;
    uint256 constant IC31y = 21438823985984507899566182138199886376121739199000643081867854656908054531133;
    
    uint256 constant IC32x = 17917677261605950435522921038736642870965167177461110100732359088102383231190;
    uint256 constant IC32y = 15117798700988017015471009974228554301171740068576756488934120969140413054889;
    
    uint256 constant IC33x = 2023876913106249380927705039650892661517609251931473403802168358096421484515;
    uint256 constant IC33y = 9474199118867212877660883478980180285242493967864992857577409210599916051635;
    
    uint256 constant IC34x = 2550672796320084780402362756060571943618059400344199704368645633889042335670;
    uint256 constant IC34y = 10840373992179629239146422845916445346945746985155360082366518867166399494370;
    
    uint256 constant IC35x = 21715686126966194557187397424725978056629091284407925100362256624871707713307;
    uint256 constant IC35y = 13113598499173477565349175338995686910826979361829537337728555853117287381495;
    
    uint256 constant IC36x = 6740900292204369374864521598089064890766414851800898877785239614158645145279;
    uint256 constant IC36y = 3176433075051465391458083220645293451791796505062452461543505828193081491378;
    
 
    // Memory data
    uint16 constant pVk = 0;
    uint16 constant pPairing = 128;

    uint16 constant pLastMem = 896;

    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[36] calldata _pubSignals) public view returns (bool) {
        assembly {
            function checkField(v) {
                if iszero(lt(v, r)) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }
            
            // G1 function to multiply a G1 value(x,y) to value in an address
            function g1_mulAccC(pR, x, y, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }

            function checkPairing(pA, pB, pC, pubSignals, pMem) -> isOk {
                let _pPairing := add(pMem, pPairing)
                let _pVk := add(pMem, pVk)

                mstore(_pVk, IC0x)
                mstore(add(_pVk, 32), IC0y)

                // Compute the linear combination vk_x
                
                g1_mulAccC(_pVk, IC1x, IC1y, calldataload(add(pubSignals, 0)))
                
                g1_mulAccC(_pVk, IC2x, IC2y, calldataload(add(pubSignals, 32)))
                
                g1_mulAccC(_pVk, IC3x, IC3y, calldataload(add(pubSignals, 64)))
                
                g1_mulAccC(_pVk, IC4x, IC4y, calldataload(add(pubSignals, 96)))
                
                g1_mulAccC(_pVk, IC5x, IC5y, calldataload(add(pubSignals, 128)))
                
                g1_mulAccC(_pVk, IC6x, IC6y, calldataload(add(pubSignals, 160)))
                
                g1_mulAccC(_pVk, IC7x, IC7y, calldataload(add(pubSignals, 192)))
                
                g1_mulAccC(_pVk, IC8x, IC8y, calldataload(add(pubSignals, 224)))
                
                g1_mulAccC(_pVk, IC9x, IC9y, calldataload(add(pubSignals, 256)))
                
                g1_mulAccC(_pVk, IC10x, IC10y, calldataload(add(pubSignals, 288)))
                
                g1_mulAccC(_pVk, IC11x, IC11y, calldataload(add(pubSignals, 320)))
                
                g1_mulAccC(_pVk, IC12x, IC12y, calldataload(add(pubSignals, 352)))
                
                g1_mulAccC(_pVk, IC13x, IC13y, calldataload(add(pubSignals, 384)))
                
                g1_mulAccC(_pVk, IC14x, IC14y, calldataload(add(pubSignals, 416)))
                
                g1_mulAccC(_pVk, IC15x, IC15y, calldataload(add(pubSignals, 448)))
                
                g1_mulAccC(_pVk, IC16x, IC16y, calldataload(add(pubSignals, 480)))
                
                g1_mulAccC(_pVk, IC17x, IC17y, calldataload(add(pubSignals, 512)))
                
                g1_mulAccC(_pVk, IC18x, IC18y, calldataload(add(pubSignals, 544)))
                
                g1_mulAccC(_pVk, IC19x, IC19y, calldataload(add(pubSignals, 576)))
                
                g1_mulAccC(_pVk, IC20x, IC20y, calldataload(add(pubSignals, 608)))
                
                g1_mulAccC(_pVk, IC21x, IC21y, calldataload(add(pubSignals, 640)))
                
                g1_mulAccC(_pVk, IC22x, IC22y, calldataload(add(pubSignals, 672)))
                
                g1_mulAccC(_pVk, IC23x, IC23y, calldataload(add(pubSignals, 704)))
                
                g1_mulAccC(_pVk, IC24x, IC24y, calldataload(add(pubSignals, 736)))
                
                g1_mulAccC(_pVk, IC25x, IC25y, calldataload(add(pubSignals, 768)))
                
                g1_mulAccC(_pVk, IC26x, IC26y, calldataload(add(pubSignals, 800)))
                
                g1_mulAccC(_pVk, IC27x, IC27y, calldataload(add(pubSignals, 832)))
                
                g1_mulAccC(_pVk, IC28x, IC28y, calldataload(add(pubSignals, 864)))
                
                g1_mulAccC(_pVk, IC29x, IC29y, calldataload(add(pubSignals, 896)))
                
                g1_mulAccC(_pVk, IC30x, IC30y, calldataload(add(pubSignals, 928)))
                
                g1_mulAccC(_pVk, IC31x, IC31y, calldataload(add(pubSignals, 960)))
                
                g1_mulAccC(_pVk, IC32x, IC32y, calldataload(add(pubSignals, 992)))
                
                g1_mulAccC(_pVk, IC33x, IC33y, calldataload(add(pubSignals, 1024)))
                
                g1_mulAccC(_pVk, IC34x, IC34y, calldataload(add(pubSignals, 1056)))
                
                g1_mulAccC(_pVk, IC35x, IC35y, calldataload(add(pubSignals, 1088)))
                
                g1_mulAccC(_pVk, IC36x, IC36y, calldataload(add(pubSignals, 1120)))
                

                // -A
                mstore(_pPairing, calldataload(pA))
                mstore(add(_pPairing, 32), mod(sub(q, calldataload(add(pA, 32))), q))

                // B
                mstore(add(_pPairing, 64), calldataload(pB))
                mstore(add(_pPairing, 96), calldataload(add(pB, 32)))
                mstore(add(_pPairing, 128), calldataload(add(pB, 64)))
                mstore(add(_pPairing, 160), calldataload(add(pB, 96)))

                // alpha1
                mstore(add(_pPairing, 192), alphax)
                mstore(add(_pPairing, 224), alphay)

                // beta2
                mstore(add(_pPairing, 256), betax1)
                mstore(add(_pPairing, 288), betax2)
                mstore(add(_pPairing, 320), betay1)
                mstore(add(_pPairing, 352), betay2)

                // vk_x
                mstore(add(_pPairing, 384), mload(add(pMem, pVk)))
                mstore(add(_pPairing, 416), mload(add(pMem, add(pVk, 32))))


                // gamma2
                mstore(add(_pPairing, 448), gammax1)
                mstore(add(_pPairing, 480), gammax2)
                mstore(add(_pPairing, 512), gammay1)
                mstore(add(_pPairing, 544), gammay2)

                // C
                mstore(add(_pPairing, 576), calldataload(pC))
                mstore(add(_pPairing, 608), calldataload(add(pC, 32)))

                // delta2
                mstore(add(_pPairing, 640), deltax1)
                mstore(add(_pPairing, 672), deltax2)
                mstore(add(_pPairing, 704), deltay1)
                mstore(add(_pPairing, 736), deltay2)


                let success := staticcall(sub(gas(), 2000), 8, _pPairing, 768, _pPairing, 0x20)

                isOk := and(success, mload(_pPairing))
            }

            let pMem := mload(0x40)
            mstore(0x40, add(pMem, pLastMem))

            // Validate that all evaluations ∈ F
            
            checkField(calldataload(add(_pubSignals, 0)))
            
            checkField(calldataload(add(_pubSignals, 32)))
            
            checkField(calldataload(add(_pubSignals, 64)))
            
            checkField(calldataload(add(_pubSignals, 96)))
            
            checkField(calldataload(add(_pubSignals, 128)))
            
            checkField(calldataload(add(_pubSignals, 160)))
            
            checkField(calldataload(add(_pubSignals, 192)))
            
            checkField(calldataload(add(_pubSignals, 224)))
            
            checkField(calldataload(add(_pubSignals, 256)))
            
            checkField(calldataload(add(_pubSignals, 288)))
            
            checkField(calldataload(add(_pubSignals, 320)))
            
            checkField(calldataload(add(_pubSignals, 352)))
            
            checkField(calldataload(add(_pubSignals, 384)))
            
            checkField(calldataload(add(_pubSignals, 416)))
            
            checkField(calldataload(add(_pubSignals, 448)))
            
            checkField(calldataload(add(_pubSignals, 480)))
            
            checkField(calldataload(add(_pubSignals, 512)))
            
            checkField(calldataload(add(_pubSignals, 544)))
            
            checkField(calldataload(add(_pubSignals, 576)))
            
            checkField(calldataload(add(_pubSignals, 608)))
            
            checkField(calldataload(add(_pubSignals, 640)))
            
            checkField(calldataload(add(_pubSignals, 672)))
            
            checkField(calldataload(add(_pubSignals, 704)))
            
            checkField(calldataload(add(_pubSignals, 736)))
            
            checkField(calldataload(add(_pubSignals, 768)))
            
            checkField(calldataload(add(_pubSignals, 800)))
            
            checkField(calldataload(add(_pubSignals, 832)))
            
            checkField(calldataload(add(_pubSignals, 864)))
            
            checkField(calldataload(add(_pubSignals, 896)))
            
            checkField(calldataload(add(_pubSignals, 928)))
            
            checkField(calldataload(add(_pubSignals, 960)))
            
            checkField(calldataload(add(_pubSignals, 992)))
            
            checkField(calldataload(add(_pubSignals, 1024)))
            
            checkField(calldataload(add(_pubSignals, 1056)))
            
            checkField(calldataload(add(_pubSignals, 1088)))
            
            checkField(calldataload(add(_pubSignals, 1120)))
            

            // Validate all evaluations
            let isValid := checkPairing(_pA, _pB, _pC, _pubSignals, pMem)

            mstore(0, isValid)
             return(0, 0x20)
         }
     }
 }
